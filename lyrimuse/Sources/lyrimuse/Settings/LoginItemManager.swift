import LyrimuseCore
import Foundation

// 装/卸这个 App 自己的 LaunchAgent。不用 SMAppService——打包成 .app 后虽然已经满足
// SMAppService 的前提(plist 放 Contents/Library/LaunchAgents/),但迁移是另一件事,
// 继续用已经跑得好好的经典 LaunchAgent plist 方案,不顺带引入新的失败模式。直接写
// plist 到 ~/Library/LaunchAgents,用户在菜单里点"开机启动"就装上/卸掉,不用自己敲
// launchctl 命令。
//
// RunAtLoad=true、不写 KeepAlive:跟 collector 那种无人值守后台服务不同,这是用户会主动
// Cmd-Q 退出的前台 GUI 工具——KeepAlive=true 会导致退出后立刻被拉起,体验是错的。
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private let label = "me.yudaotor.lyrimuse"
    // LaunchAgent 应该始终指向 build.sh 真正安装的位置(跟 collector 的 bin/collector
    // 同一个约定),不是当前运行进程的路径——开发时用 swift run/直接跑 .build/debug 的
    // 那次,进程路径是临时调试目录,不该拿来当"以后开机启动"的目标。优先信任当前正在
    // 运行的可执行文件自己的路径:只要它就是 build.sh 真正安装的那份(以
    // /Contents/MacOS/lyrimuse 结尾),说明它自己就在正确的安装位置上,不管仓库实际
    // clone 到哪里都对;只有路径不匹配(说明是临时调试二进制,没有真正"已安装"的位置)
    // 才退回下面的默认兜底路径。
    private var installedExecutablePath: String {
        if let running = Bundle.main.executablePath, running.hasSuffix("/Contents/MacOS/lyrimuse") {
            return running
        }
        return URL(fileURLWithPath: "/Applications/Lyrimuse.app/Contents/MacOS/lyrimuse").path
    }
    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { uninstall() }
    }

    private func install() {
        // App 的 stdout / stderr 落到自己的文件(2026-09-05,LogFiles.appStderr):此前跟 collector
        // 共用 lyrimuse.log,两个进程两种格式两种时区混在一个文件里,launchctl 子进程漏出来的报错
        // 也分不清是谁的。这份 plist 每次启动都重写(AppDelegate),但 launchd 只在 job **bootstrap** 时读它
        // —— kickstart 不重读(2026-09-05 装机实测:plist 已是新路径,`launchctl print` 里 stderr
        // 仍是旧文件),所以改动要到下次登录(或 bootout + bootstrap)才生效。诊断导出会把这个
        // 文件的最后 100 行附上。
        let logPath = LogFiles.appStderr.path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedExecutablePath],
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL)
            // ⚠️ **刻意不 bootstrap**(2026-09-03 第二次修「点一下就闪退」)。
            //
            // 原来这里有一句 `launchctl bootstrap gui/<uid> <plist>`,而 plist 里
            // `RunAtLoad = true` —— bootstrap 的一瞬间 launchd 就**再起一个 lyrimuse**。
            // App 已经在跑着,于是同一个 bundle 出现两个进程,老的那个让位退出:日志里是
            // `Process exited: voluntary`(不是信号),新进程在**同一秒**启动。用户看到的
            // 就是窗口凭空消失 = "闪退",而且这次连 SIGTERM 都没有,更难查。
            //
            // 而 bootstrap 本来就不需要:plist 落在 ~/Library/LaunchAgents 里,launchd
            // **下次登录**会自己加载它 —— 那正是"开机启动"这个开关承诺的全部内容。本次
            // 会话里注册与否对用户没有任何可观察差别(没有 KeepAlive,退出不会被拉起)。
        } catch {
            // 装载失败(权限/磁盘问题):个人小工具,静默失败可接受,不额外弹窗打扰——
            // 用户下次打开菜单时开关状态(读自 AppSettings)会如实反映"没真正装上"。
        }
    }

    /// ⚠️ **这个函数只删文件,不碰 launchctl** —— 2026-09-03 为此修了两次,记清楚原因。
    ///
    /// 第一版:无条件 `launchctl bootout gui/<uid>/me.yudaotor.lyrimuse`。而这个 App
    /// **本身就是那个 job**(build.sh 装完走 bootstrap + kickstart,开机自启同理),于是
    /// 关掉开关 = 让 launchd 给自己发一记 SIGTERM。退出是干净的
    /// (`RBSProcessExitStatus| domain:signal(2) code:SIGTERM(15)`)、**不生成 crash
    /// report**,所以用户只看到"点一下就闪退",完全联想不到是这个开关。
    ///
    /// 第二版加了"这个 job 是不是我自己"的判断,只治好了关的方向 —— 开的方向还有一个
    /// 对称的坑(install() 里的 bootstrap 会再拉起一个实例,见那边)。
    ///
    /// 第三版(现在)直接砍掉整类问题:**一个偏好开关不该启动或杀死任何进程**。plist 文件
    /// 就是"下次登录启不启动"的全部机制 —— 删掉它,launchd 下次登录读不到,就不会启动。
    /// 本次会话里那个 job 继续挂着注册状态是无害的(没有 KeepAlive,退出后不会被拉起)。
    ///
    /// ⚠️ 也**不要**改用 `launchctl disable`:那是持久化黑名单、跨重装依然生效,以后重新
    /// 打开开关时 bootstrap 会被静默拒绝,是个更难查的坑。
    private func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
