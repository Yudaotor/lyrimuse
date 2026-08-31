import Foundation
import LyrimuseCore
import OSLog

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

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "collector-service")

    /// 上一次 install() 成功时,装进 launchd 的那个 collector 二进制的身份。
    ///
    /// 机器本地状态,**必须**进 `ConfigPortability.machineLocalDefaultsKeys`:它描述的是
    /// "这台机器上现在装着哪个二进制",跟着备份搬到新机器只会让新机器误以为"没变过"、
    /// 跳过那次本来必须做的重装。
    static let installedFingerprintKey = "np:collectorInstalledFingerprint"

    /// 用户意图开关的 key。这里直读 UserDefaults 而不是碰 `AppSettings.shared` ——
    /// 这个类型不是 @MainActor(见类型注释),reconcile 整段跑在 operationQueue 上。
    private static let enabledKey = "np:collectorServiceEnabled"

    /// 当前 bundle 里那个 collector 二进制的身份指纹:路径 + 大小 + mtime。
    ///
    /// 为什么不算 cdhash:`codesign -dvvv` 要 fork 一个进程、读整个二进制算哈希,而这里只
    /// 需要回答"跟上次装的是不是同一个文件"。每次打包都是重新 `cp` + 重新 ad-hoc 签名,
    /// mtime 必变;大小和路径再兜一层。stat 一次就够,启动路径上零感知。
    ///
    /// 拿不到(文件不存在——比如直接 `swift build` 跑、没走 build.sh 打包)时返回 nil,
    /// 调用方据此退回"只看服务在不在跑"。
    private static func currentBinaryFingerprint() -> String? {
        let path = bundledCollectorPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970 * 1000))"
    }

    /// 启动时对账一次:collector 该跑而没跑、或者它的二进制被换过,就重装这个 job。
    ///
    /// **这是 Sparkle 自动更新之后唯一的兜底。** 没有它的后果是坐实过的(记录在
    /// `lyrimuse/build.sh` 里 COLLECTOR_LABEL 那段注释):
    ///   1. 更新把 `Contents/Resources/collector` 换成新的 ad-hoc 签名二进制,cdhash 必变;
    ///   2. 正在跑的老 collector 因为二进制被换掉,下次缺页时被 SIGKILL;
    ///   3. launchd(KeepAlive=true)想拉起新的,但它给这个 job 缓存的 LWCR(Lightweight
    ///      Code Requirement)还绑在**旧** cdhash 上 —— 新二进制被内核直接拒绝,崩溃报告写
    ///      "CODESIGNING / Launch Constraint Violation + SIGKILL (Code Signature Invalid)",
    ///      launchctl 那边是 exit 78 EX_CONFIG / spawn failed;
    ///   4. KeepAlive 一直重试一直失败(实测抓到时 runs 已 127 次),collector 就此永久躺平
    ///      —— 歌词解析、scrobble、relay 全停,而 App 本身活得好好的,表现成"这首歌一直
    ///      没歌词",极难联想到是"刚才那次自动更新"。
    /// build.sh 为本地构建做了这个自愈(bootout+bootstrap),但 Sparkle / Homebrew cask /
    /// 手动拖 .app 覆盖这三条路都不经过 build.sh。`install()` 本身就是完整的
    /// bootout→写 plist→bootstrap 三级自愈,这里缺的只是一个启动时的触发点。
    ///
    /// 判据用**二进制指纹**而不是"服务在不在跑":更新之后老进程往往还活着(要等下一次缺页
    /// 才被 SIGKILL),那一刻 isRunning 仍是 true,只看运行状态会整个错过这次更新,而等它
    /// 真死掉时 App 早就启动完了、没有人再检查。
    ///
    /// 不阻塞启动:整段扔进已有的串行队列(它同时保证不会跟设置页/引导页的装卸并发)。
    public static func reconcileAfterLaunch() {
        operationQueue.async {
            // 用户自己关掉了后台服务就什么都不做 —— 这里是修"该跑却跑不起来",不是替用户
            // 决定要不要跑。默认值 false 与 AppSettings 一致(没装过就是没装)。
            guard UserDefaults.standard.bool(forKey: enabledKey) else { return }

            let fingerprint = currentBinaryFingerprint()
            let recorded = UserDefaults.standard.string(forKey: installedFingerprintKey)
            // fingerprint 为 nil(拿不到二进制)时不当成"变了" —— 那是 `swift build` 直跑
            // 这类没有 bundle 的场景,重装也装不出东西来,退回只看运行状态。
            let binaryChanged = fingerprint != nil && fingerprint != recorded
            let running = isRunning
            guard binaryChanged || !running else { return }

            logger.notice(
                "collector reconcile on launch: binaryChanged=\(binaryChanged, privacy: .public) running=\(running, privacy: .public) — reinstalling job")
            install()
        }
    }

    /// install() 结束时记账。只有真的跑起来了才写指纹 —— 装完仍起不来时把它清掉,下次启动
    /// 会再试一遍,而不是因为"指纹对得上"就再也不管了。
    private static func recordInstalledFingerprint() {
        if isRunning, let fingerprint = currentBinaryFingerprint() {
            UserDefaults.standard.set(fingerprint, forKey: installedFingerprintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: installedFingerprintKey)
        }
    }

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

    /// 打包进这份 App 里的 collector 二进制,自己报出来的版本号(`collector version`,
    /// 对应 Go 侧 main.go 的 clientVersion)——2026-08-31 加,给设置页"后台采集服务"卡片
    /// 检测"App 本体版本"跟"这份 App 实际打包的 collector 版本"是否一致用。
    ///
    /// 起因是 clientVersion 那个字面量一直是手动同步的,发布时忘记同步过至少一次
    /// (v1.3.0 那次漏了,见 clientVersion 声明处注释),当时没有任何机制能让人自己发现
    /// 这个不一致。这里直接运行一次打包好的二进制拿它自己报的版本号,不是猜/不是解析
    /// 文件名——跟"这个二进制到底是哪个版本"这件事只有它自己说了算。
    ///
    /// 独立于上面那份 currentBinaryFingerprint/installedFingerprintKey 机制:那一套解决
    /// 的是"运行中的旧进程 vs 磁盘上被换掉的新二进制"(自动更新之后的自愈重装),这里解决
    /// 的是"这次打包时,collector 有没有跟 App 一起同步升过版本号"——两者答的是不同的问题,
    /// 不能互相替代。
    ///
    /// 拿不到(文件不存在/执行失败/输出为空)时返回 nil——不确定就不要瞎猜,调用方应该
    /// 把 nil 当"这次没法判断"处理,不要当成"版本不一致"报出来。
    public static func bundledCollectorVersion() -> String? {
        let (status, output) = runCapturing(bundledCollectorPath, ["version"])
        guard status == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
        // 三条成功路径(bootstrap 直接起来 / kickstart 之后起来 / LWCR 重试之后起来)各自
        // early return,记账放 defer 里一处收口,免得漏掉哪一条。
        defer { recordInstalledFingerprint() }
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

        // plist 里 RunAtLoad=true,所以 bootstrap 本身就会把进程拉起来 —— 实测 78~102ms
        // 就是 running。**不要**在这里跟一句 `kickstart -k`。
        //
        // 2026-08-15 实测:那句 kickstart 让整个安装从 ~100ms 变成 ~10.1 秒,三次测量
        // 稳定复现(10114 / 10121 / 10087ms)。`-k` 的意思是"先杀掉正在跑的再启动",而它
        // 杀的正是 bootstrap 刚刚拉起来的那个新进程;那 10 秒是 launchd 等进程响应 SIGTERM
        // 的固定宽限期。用户在引导页点"启用"之后盯着转圈,就是在等这个。
        //
        // 轮询代替盲等 sleep(1):起来了立刻返回,没起来才逐级升级手段。
        if waitUntilRunning() { return }

        // 没起来才踢一脚 —— 这时候 kickstart 的代价是值得付的(job 注册了但进程没跑)。
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        if waitUntilRunning() { return }

        // 还是不行:launchd 给这个 job 缓存了上一次运行遗留的 LWCR(Lightweight Code
        // Requirement) codesigning 约束，绑定的是旧二进制的 cdhash；每次重新打包都是新的
        // ad-hoc 签名，cdhash 必然变化，bootstrap/kickstart 本身不会刷新这个约束——跟
        // lyrimuse-collector/build.sh、lyrimuse/build.sh 里同款自愈逻辑一致，这里复用同一套
        // 重试思路，不重新发明。
        run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        _ = waitUntilRunning()
    }

    /// 轮询等这个 job 真的跑起来。等到了返回 true,超时返回 false。
    ///
    /// 取代原来的 `Thread.sleep(1)` 盲等:正常情况下 ~100ms 就能确认(实测 78~102ms),
    /// 盲等 1 秒是白白让用户多看 900ms 转圈;而真出问题时 1 秒又不够。
    private static func waitUntilRunning(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return isRunning
    }

    private static func uninstall() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        // 卸了就别留指纹:留着的话,用户下次开启服务前如果 App 更新过,reconcile 会拿一个
        // "上次装的是谁"的陈旧记录去比,徒增一次判断歧义。
        UserDefaults.standard.removeObject(forKey: installedFingerprintKey)
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
