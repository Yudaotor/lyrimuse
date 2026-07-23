import Foundation

// 装/卸/查询 collector 这个后台常驻服务的 LaunchAgent。跟 LoginItemManager 管这个 App
// 自己的 LaunchAgent是同一种模式，但目标不同：LoginItemManager 装的是"这个 App 要不要
// 开机自动启动"——用户随时会 Cmd-Q 退出，RunAtLoad=true 不设 KeepAlive；这里装的是
// collector，一个真正无人值守的后台服务（读播放状态、抓歌词/封面写本地缓存），没有它
// 悬浮歌词/灵动岛什么都显示不出来，所以 KeepAlive=true（崩了自动拉起）。
//
// collector 二进制打包进 .app 里（build.sh 在 swift build 之后额外 go build 一份，
// 拷进 Contents/Resources/collector）——这样才能像 LoginItemManager 认自己一样，通过
// Bundle.main.bundleURL 精确知道它在哪，不需要用户手动 clone 到哪都要自己拼路径。
//
// 不用 @MainActor（跟 CollectorControl 一样，只是 Process/FileManager 操作，没有碰任何
// UI 状态）——install() 内部可能因为 kickstart 失败重试而 sleep 一两秒，必须能在
// Task.detached 的后台线程里跑，不能被绑在 MainActor 上。
public enum CollectorServiceManager {
    public static let label = CollectorControl.label

    private static var bundledCollectorPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/collector").path
    }
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse")

    // 服务是否真的在跑——不是看 AppSettings 里持久化的"用户意图"，是直接问 launchd。
    // Settings 页面和引导页面的状态展示都靠这个，覆盖"装了但没跑起来"这种中间态。
    public static var isRunning: Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) == 0
    }

    // 供 AppSettings.collectorServiceEnabled 的 didSet 调用——fire-and-forget，不阻塞
    // 调用方（跟 CollectorControl.restartAndWaitAsync() 同样的理由：launchctl 操作 +
    // 失败重试的 sleep 可能要一两秒，不该占住调用它的那个线程）。
    public static func setEnabled(_ enabled: Bool) {
        Task.detached(priority: .userInitiated) {
            if enabled { install() } else { uninstall() }
        }
    }

    // 需要拿到"真的装完了没有"这个结果时用——Settings/引导页面的按钮点下去之后要等它
    // 跑完、刷新状态展示，不能像上面那样纯 fire-and-forget。
    @discardableResult
    public static func setEnabledAndWait(_ enabled: Bool) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            if enabled { install() } else { uninstall() }
            return isRunning
        }.value
    }

    private static func install() {
        // ConfigStore/FeatureSettingsStore 写配置文件、collector 自己写歌词/封面缓存，
        // 都假设这个目录已经存在——AppDelegate 启动时也会保证一次，这里是第二道保险
        // （谁先跑到都行，createDirectory 本身是幂等的）。
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/lyrimuse.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [bundledCollectorPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 不管这个 label 之前是怎么装上的（用户手动跑过旧版 README 那段 shell，还是这次
        // 机制自己之前装的），统一先 bootout 再写新 plist、bootstrap——reload 一次总是
        // 安全的，不用分辨来源。
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        guard (try? data.write(to: plistURL)) != nil else { return }
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        Thread.sleep(forTimeInterval: 1)

        if !isRunning {
            // kickstart 有时会静默失败——launchd 给这个 job 缓存了上一次运行遗留的 LWCR
            // (Lightweight Code Requirement) codesigning 约束，绑定的是旧二进制的
            // cdhash；每次重新打包都是新的 ad-hoc 签名，cdhash 必然变化，
            // bootstrap/kickstart 本身不会刷新这个约束——跟 lyrimuse-collector/build.sh、
            // lyrimuse/build.sh 里同款自愈逻辑一致，这里复用同一套重试思路，不重新发明。
            run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
            Thread.sleep(forTimeInterval: 1)
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
            Thread.sleep(forTimeInterval: 1)
            run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        }
    }

    private static func uninstall() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
