import Foundation

// 装/卸这个 App 自己的 LaunchAgent。不用 SMAppService——那个要求 plist 放在 .app 包内部
// (Contents/Library/LaunchAgents/),跟"不打包成 .app"的决定冲突。直接写经典 LaunchAgent
// plist 到 ~/Library/LaunchAgents,用户在菜单里点"开机启动"就装上/卸掉,不用自己敲
// launchctl 命令。
//
// RunAtLoad=true、不写 KeepAlive:跟 collector 那种无人值守后台服务不同,这是用户会主动
// Cmd-Q 退出的前台 GUI 工具——KeepAlive=true 会导致退出后立刻被拉起,体验是错的。
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private let label = "com.chenyuhao.applemusic-desktop-lyrics"
    // 硬编码安装路径(跟 collector 的 bin/collector 同一个约定),不用当前运行进程的
    // 路径——开发时用 swift run/直接跑 .build/debug 的那次,进程路径是临时调试目录,
    // LaunchAgent 应该始终指向 build.sh 真正安装的位置。
    private var installedExecutablePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("applemusic-nowplaying/bin/desktop-lyrics").path
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
            .appendingPathComponent("Library/Logs/desktop-lyrics.log").path
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
