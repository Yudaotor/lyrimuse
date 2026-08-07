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

    /// 「喜欢」这件事只有 Apple Music 有——QQ 音乐/网易云音乐没有 AppleScript 支持,
    /// media-control 走的系统级 MediaRemote 也只有播放控制、没有"收藏"这个概念。所以下面
    /// 这两个函数不走 dispatch 的双后端分派,只发 AppleScript;调用方负责先确认当前播放器
    /// 确实是 Apple Music、以及自动化权限已经拿到(跟上面几个动作同一个约定)。
    ///
    /// ⚠️ 属性名在不同 macOS 上不一样,而且**必须分两次调用、不能写在同一段 try 里**。
    /// 这台 macOS 27 的 Music.app 脚本字典里已经没有 `loved` 了,同一个属性(四字符码都是
    /// `pLov`)改名成了 `favorited`;而更早的系统上只有 `loved`。AppleScript 是整段先编译
    /// 再执行的,字典里不存在的属性会让**整段**编译失败,`on error` 根本轮不到执行,所以
    /// 只能先发一段 favorited 版本、失败了再发一段 loved 版本。
    private static let favoritedPropertyNames = ["favorited", "loved"]

    /// 读当前曲目的"喜欢"状态。读不到(不是 Apple Music / 没权限 / 当前没有曲目 / 两个
    /// 属性名都不认)时返回 nil,调用方据此决定要不要显示这个按钮。
    ///
    /// 会阻塞到子进程结束,**不要在主线程调用**。
    public static func favoritedState() -> Bool? {
        for name in favoritedPropertyNames {
            guard let out = runAppleScriptCapturing(
                #"tell application "Music" to get \#(name) of current track"#
            ) else { continue }
            switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": return true
            case "false": return false
            default: continue
            }
        }
        return nil
    }

    /// 设置当前曲目的"喜欢"状态。跟上面同一套属性名兜底。
    public static func setFavorited(_ value: Bool) {
        for name in favoritedPropertyNames {
            if runAppleScriptCapturing(
                #"tell application "Music" to set \#(name) of current track to \#(value)"#
            ) != nil {
                return
            }
        }
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

    /// 跟 runAppleScript 的区别:这个要**等**子进程结束并取回 stdout,失败(非零退出)返回
    /// nil。上面那个是"发完就不管"的写指令,这个给需要读回值、或者需要知道这条脚本到底
    /// 有没有成功的场景用(见 favoritedState/setFavorited 的属性名兜底)。
    ///
    /// 会阻塞到子进程结束,调用方负责别在主线程上调。
    private static func runAppleScriptCapturing(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr 丢掉:属性名不认时 osascript 会往 stderr 打一段编译错误,那是这里预期内的
        // 兜底路径,不该污染 App 自己的日志。
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
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
