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
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/lyrimuse.log").path
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
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        } catch {
            // 装载失败(权限/磁盘问题):个人小工具,静默失败可接受,不额外弹窗打扰——
            // 用户下次打开菜单时开关状态(读自 AppSettings)会如实反映"没真正装上"。
        }
    }

    private func uninstall() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
