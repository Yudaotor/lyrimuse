import AppKit
import Darwin
import LyrimuseCore
import OSLog

/// 启动时 App 在磁盘映像里或 App Translocation 临时位置上(`AppLocation`),问一次要不要移到「应用程序」文件夹:
/// 移的话拷过去(旧版先进废纸篓)、去掉隔离标记,等本进程退出后推出原来的磁盘映像、从新位置重开;选「不了」这一版不再问。
/// 在 `applicationWillFinishLaunching` 里、请走旧实例和装引擎、开窗口之前跑(LetsMove 也在这一步):弹窗要等 App 进入
/// 启动流程才收得到点击;还没启动起来时(`AppEntry.main()` 里)弹出来的窗口点不动。
/// 做法参考 LetsMove。见 15 章决策 110。
enum AppLocationPrompt {
    /// 对哪一版说过「不了」(CFBundleShortVersionString)。
    static let declinedVersionKey = "np:appMoveDeclinedVersion"
    /// 验证用:设了就把这个目录当「应用程序」文件夹、不关别的实例、不抢前台,重开那一步只把要打开的路径写进这个目录下的
    /// `relaunched.txt`(不真的打开);不管结果如何,结果写进 `outcome.txt` 就退出,不接着启动整个 App(同一身份的第二个
    /// 实例会改写引擎配置)。
    static let testDirectoryEnvironmentKey = "LYRIMUSE_APP_MOVE_TEST_DIR"
    static let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "app-location")

    enum Outcome: Equatable {
        case notNeeded
        case declined
        case cancelled
        case moved(destination: URL, replaced: URL?)
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// App 包此刻所在位置的判定。只读卷上才去问 `hdiutil`(平时的启动不多花这一下)。
    static func kind(of bundle: URL) -> AppLocation.Kind {
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey])
        let readOnly = values?.volumeIsReadOnly ?? false
        var mountPoints: [String] = []
        if readOnly, let result = ProcessRunner.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 10), result.succeeded {
            mountPoints = AppLocation.diskImageMountPoints(hdiutilInfoPlist: result.stdout)
        }
        return AppLocation.classify(bundlePath: bundle.path, volumeIsReadOnly: readOnly, volumePath: values?.volume?.path,
                                    diskImageMountPoints: mountPoints)
    }

    @MainActor static func runAtLaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", !CommandLine.arguments.contains("--unregister-login-item") else { return }
        let location = kind(of: bundle)
        let testDirectory = ProcessInfo.processInfo.environment[testDirectoryEnvironmentKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard AppLocation.shouldPrompt(location, declinedVersion: UserDefaults.standard.string(forKey: declinedVersionKey),
                                       currentVersion: currentVersion) else {
            if let testDirectory { finishTest(in: testDirectory, "skipped \(location)") }
            return
        }
        logger.notice("app location: running from \(String(describing: location), privacy: .public), asking to move")
        let outcome = ask(location: location, source: bundle, into: testDirectory ?? applicationsDirectory, activate: testDirectory == nil)
        logger.notice("app location: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .notNeeded, .cancelled:
            break
        case .declined:
            UserDefaults.standard.set(currentVersion, forKey: declinedVersionKey)
        case let .failed(message):
            showFailure(message, activate: testDirectory == nil)
        case let .moved(destination, _):
            if let testDirectory { FileIO.write("\(outcome)\n", to: testDirectory.appendingPathComponent("outcome.txt")) }
            if location == .translocated, testDirectory == nil { trashTranslocatedOriginal(of: bundle) }
            relaunch(destination, location: location, testDirectory: testDirectory)
        }
        if let testDirectory { finishTest(in: testDirectory, String(describing: outcome)) }
    }

    private static func finishTest(in directory: URL, _ outcome: String) -> Never {
        FileIO.write(outcome + "\n", to: directory.appendingPathComponent("outcome.txt"))
        exit(0)
    }

    /// 弹窗问,选了移动就当场搬。`answer` 不为 nil 时不弹窗、直接按它走(深链验证用)。
    @MainActor static func ask(location: AppLocation.Kind, source: URL, into directory: URL, activate: Bool,
                               answer: Bool? = nil) -> Outcome {
        guard location != .normal else { return .notNeeded }
        let move: Bool
        if let answer {
            move = answer
        } else {
            let alert = NSAlert()
            if case .diskImage = location {
                alert.messageText = L10n.t("Lyrimuse 正在从磁盘映像运行")
                alert.informativeText = L10n.t("移到「应用程序」文件夹后才能自动更新，推出磁盘映像时它也不会退出")
            } else {
                alert.messageText = L10n.t("Lyrimuse 正在从临时位置运行")
                alert.informativeText = L10n.t("移到「应用程序」文件夹后才能自动更新")
            }
            alert.addButton(withTitle: L10n.t("移到应用程序文件夹并重新打开"))
            alert.addButton(withTitle: L10n.t("不了"))
            if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
            move = alert.runModal() == .alertFirstButtonReturn
        }
        guard move else { return .declined }
        return perform(source: source, into: directory)
    }

    /// 能直接写就自己搬;要管理员权限就交给系统的授权框跑 `AppLocation.privilegedMoveScript`。
    @MainActor static func perform(source: URL, into directory: URL) -> Outcome {
        let name = source.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        guard AppBundleMover.needsPrivileges(directory: directory, bundleName: name) else {
            do {
                let result = try AppBundleMover().move(source, into: directory)
                return .moved(destination: result.destination, replaced: result.replaced)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let trashTarget = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/\(source.deletingPathExtension().lastPathComponent) \(stamp).app")
        let script = AppLocation.privilegedMoveScript(
            source: source.path, destination: destination.path,
            temporary: directory.appendingPathComponent(AppLocation.temporaryName(for: name)).path, trashTarget: trashTarget.path)
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(AppLocation.appleScriptLiteral(script)) with administrator privileges")?
            .executeAndReturnError(&error)
        if let error {
            // -128:用户在授权框里点了取消,不算失败。
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "")
        }
        let replaced = FileManager.default.fileExists(atPath: trashTarget.path) ? trashTarget : nil
        return .moved(destination: destination, replaced: replaced)
    }

    @MainActor private static func showFailure(_ message: String, activate: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("没能移到「应用程序」文件夹")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("好"))
        if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
        alert.runModal()
    }

    /// 等本进程退出 → 推出磁盘映像 → 打开新位置;别的正在跑的同一 App 先请走(它退出时还要存一次设置)。
    private static func relaunch(_ destination: URL, location: AppLocation.Kind, testDirectory: URL?) {
        let mountPoint: String? = if case let .diskImage(mountPoint) = location { mountPoint } else { nil }
        let launch: String
        if let testDirectory {
            let marker = testDirectory.appendingPathComponent("relaunched.txt").path
            launch = "/bin/echo \(AppLocation.shellQuote(destination.path)) > \(AppLocation.shellQuote(marker))"
        } else {
            let me = getpid()
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: LyrimuseIdentity.bundleIdentifier)
            where other.processIdentifier != me {
                other.terminate()
            }
            launch = "/usr/bin/open \(AppLocation.shellQuote(destination.path))"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AppLocation.relaunchScript(waitingFor: getpid(), detachMountPoint: mountPoint, launch: launch)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("app location: could not start the relaunch helper: \(error.localizedDescription, privacy: .public)")
            return
        }
        exit(0)
    }

    /// Translocation 时用户真正下载下来的那一份(多半在「下载」里)也挪进废纸篓,不然下次又从那里打开、又被挂到临时位置。
    /// 取原路径用 Security 的 `SecTranslocateCreateOriginalPathForURL`(公开头文件里没有,按符号名取;取不到就不动)。
    private static func trashTranslocatedOriginal(of bundle: URL) {
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return }
        let original = unsafeBitCast(symbol, to: OriginalPath.self)
        guard let url = original(bundle as CFURL, nil)?.takeRetainedValue() as URL?,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            _ = try AppBundleMover.moveToTrash(url)
        } catch {
            logger.error("app location: could not trash the original download: \(error.localizedDescription, privacy: .public)")
        }
    }
}
