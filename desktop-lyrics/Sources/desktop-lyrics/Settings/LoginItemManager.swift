import Foundation

// 装/卸这个 App 自己的 LaunchAgent。不用 SMAppService——2026-07-18 打包成 .app 之后
// 其实已经满足 SMAppService 的前提(plist 放 Contents/Library/LaunchAgents/),但迁移
// 到 SMAppService 是另一件事、这里先只解决"路径从裸可执行文件变成 .app 包内部"这一个
// 问题,继续用已经跑得好好的经典 LaunchAgent plist 方案,不顺带引入新的失败模式。直接写
// plist 到 ~/Library/LaunchAgents,用户在菜单里点"开机启动"就装上/卸掉,不用自己敲
// launchctl 命令。
//
// RunAtLoad=true、不写 KeepAlive:跟 collector 那种无人值守后台服务不同,这是用户会主动
// Cmd-Q 退出的前台 GUI 工具——KeepAlive=true 会导致退出后立刻被拉起,体验是错的。
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private let label = "com.chenyuhao.applemusic-desktop-lyrics"
    // LaunchAgent 应该始终指向 build.sh 真正安装的位置(跟 collector 的 bin/collector
    // 同一个约定),不是当前运行进程的路径——开发时用 swift run/直接跑 .build/debug 的
    // 那次,进程路径是临时调试目录,不该拿来当"以后开机启动"的目标。
    //
    // 2026-07-17 修复:之前这里整个硬编码成 ~/applemusic-nowplaying/bin/desktop-lyrics,
    // 假设仓库固定 clone 在这个路径——clone 到别处这个开关会静默装出一个指向不存在
    // 位置的 LaunchAgent。现在优先信任当前正在运行的可执行文件自己的路径:只要它就是
    // build.sh 真正安装的那份,说明它自己就在正确的安装位置上,不管仓库实际 clone 到
    // 哪里都对;只有路径不匹配(说明这次是 swift run/.build/debug 的临时调试二进制,
    // 此时也没有真正"已安装"的位置可言)才退回默认假设。
    //
    // 2026-07-18 更新:build.sh 从"裸可执行文件装到 bin/desktop-lyrics"改成"打包成
    // DesktopLyrics.app 装到 bin/DesktopLyrics.app",判断条件和默认兜底路径都要跟着
    // 改——路径特征从"以 /bin/desktop-lyrics 结尾"变成"以 /Contents/MacOS/desktop-lyrics
    // 结尾"(不要求父目录名字面是 bin,因为真正的 .app 包结构里可执行文件永远在
    // Contents/MacOS/ 下,这一段本来就是 .app 包自己的固定结构,不需要再额外校验更上层
    // 目录名)。
    private var installedExecutablePath: String {
        if let running = Bundle.main.executablePath, running.hasSuffix("/Contents/MacOS/desktop-lyrics") {
            return running
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("applemusic-nowplaying/bin/DesktopLyrics.app/Contents/MacOS/desktop-lyrics").path
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
