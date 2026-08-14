import Foundation
import LyrimuseCore

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

    // 服务的真实状态——不是看 AppSettings 里持久化的"用户意图"，是直接问 launchd。
    // Settings 页面和引导页面的状态展示都靠这个。
    //
    // ⚠️ 2026-08-15 修:这里原来是 `run("/bin/launchctl", ["print", …]) == 0`,而那个退出码
    // 表示的是"**这个 job 注册过**",不是"进程在跑"——实测三态见 LaunchdJobState 的注释。
    // 后果是 collector 在 KeepAlive 下崩溃重启循环时,设置页一直显示绿勾"运行中"。更糟的
    // 是下面 install() 的自愈重试也用它当判据(`if !isRunning`),bootstrap 一成功就认为大功
    // 告成,那段专门为"kickstart 静默失败"写的 LWCR 重试根本轮不到执行。
    public static var state: LaunchdJobState {
        let (status, output) = runCapturing("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        return LaunchdPrintParser.parse(printExitCode: status, printOutput: output)
    }

    public static var isRunning: Bool { state.isRunning }

    // install()/uninstall() 必须互斥——2026-08-02 实测排查坐实:早先 setEnabled(_:)/
    // setEnabledAndWait(_:) 各自派发一个独立的 Task.detached,互相之间完全没有互斥。
    // AppSettings.collectorServiceEnabled 的 didSet 对"赋同一个值"依然会触发(Swift 不
    // 做 old==new 短路),而 SettingsView.toggleCollectorService/OnboardingView.
    // enableCollectorService 在 setEnabledAndWait 完成后都会回写一次
    // settings.collectorServiceEnabled = enabling——这次赋值会再触发一次
    // didSet→setEnabled(_:),派生出一个完全独立、不等待的冗余调用。如果用户在这次冗余
    // 调用还没跑完(install() 内部失败重试路径最坏可达 2-3 秒)之前就快速切换开关,足以
    // 让 install()/uninstall() 真的并发执行,其中一个的 bootstrap 用到另一个已经删除的
    // plist 路径而静默失败,最终 launchd 实际状态跟 collectorServiceEnabled 显示的对不
    // 上。改用一条专属的串行队列承载所有 install()/uninstall() 调用——不管调用方是不是
    // 冗余触发的,严格按到达顺序一个接一个执行,不再各自开一个独立、互不感知的
    // Task.detached。
    private static let operationQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.collector-service-manager", qos: .userInitiated)

    // 供 AppSettings.collectorServiceEnabled 的 didSet 调用——fire-and-forget，不阻塞
    // 调用方（跟 CollectorControl.restartAndWaitAsync() 同样的理由：launchctl 操作 +
    // 失败重试的 sleep 可能要一两秒，不该占住调用它的那个线程）；串行队列本身已经保证了
    // 不会跟别的调用并发执行,fire-and-forget 只是不阻塞调用方等它跑完。
    public static func setEnabled(_ enabled: Bool) {
        operationQueue.async {
            if enabled { install() } else { uninstall() }
        }
    }

    // 需要拿到"真的装完了没有"这个结果时用——Settings/引导页面的按钮点下去之后要等它
    // 跑完、刷新状态展示，不能像上面那样纯 fire-and-forget。用 withCheckedContinuation
    // 把串行队列上的同步操作桥接成 async,而不是像以前那样另起一个不受这条队列管辖的
    // Task.detached——否则这次"等待版"调用会绕开上面的互斥,又制造出一条新的并发路径。
    // 返回完整状态而不是 Bool:调用方要区分"装上了但起不来"(能给出具体退出码)和"压根没
    // 装上",两者该给用户的提示不一样。
    @discardableResult
    public static func setEnabledAndWait(_ enabled: Bool) async -> LaunchdJobState {
        await withCheckedContinuation { continuation in
            operationQueue.async {
                if enabled { install() } else { uninstall() }
                continuation.resume(returning: state)
            }
        }
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
        runCapturing(path, args).status
    }

    /// 跑一条命令,拿到退出码和 stdout。
    ///
    /// ⚠️ 读管道必须在 `waitUntilExit()` **之前**:管道缓冲区(64KB)写满之后子进程会阻塞在
    /// write 上永远不退出,而父进程正卡在 waitUntilExit 等它退出 —— 互相等死。原来的写法
    /// 是设了 Pipe 却从不读、直接 waitUntilExit,只是因为 launchctl 的输出一直很小才没炸
    /// (print 一份 job 约 1.6KB)。`readDataToEndOfFile()` 会一直读到子进程关闭 stdout,
    /// 之后 waitUntilExit 立刻返回。
    ///
    /// stderr 直接丢进 nullDevice 而不是另开一个 Pipe:同样是"设了不读"的死锁形状,而这里
    /// 的调用方要的信息退出码已经给全了。
    private static func runCapturing(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
