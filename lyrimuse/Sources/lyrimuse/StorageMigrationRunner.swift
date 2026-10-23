import AppKit
import Darwin
import Foundation
import LyrimuseCore
import OSLog

/// App 进程的入口:先把数据目录搬成新布局,再交给 SwiftUI。搬迁必须在任何别的代码碰 `LyrimusePaths.configDir` 之前跑完 ——
/// 那个值进程里第一次用到时就定下来,`LyrimuseApp` 的属性初值、AppDelegate、各个 `.shared` 都可能用到它。
@main
enum AppEntry {
    static func main() {
        StorageMigrationRunner.runAtLaunch()
        LyrimuseApp.main()
    }
}

/// 启动时的存储布局搬迁(Core `StorageMigration`,14 章决策 136)。有要做的才动别的进程:先请走还开着的其它 App 实例
/// (升级时旧版本可能还在跑,它退出时还要存一次设置,得等它存完、退干净),再 bootout 引擎的 launchd job、拿到引擎的单实例锁
/// (数据目录里的 `collector.lock`,引擎活着时一直攥着)才动手;拿不到就这次不搬、照旧用旧目录,下次启动再试。搬过东西就清掉引擎的安装指纹,随后的 `EngineServiceManager.reconcileAfterLaunch` 按新目录重写 plist、
/// 把引擎装回去;这次没搬成时引擎已经停了,同一次对账照样按「该跑没跑」装回去。
enum StorageMigrationRunner {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "storage-migration")

    static func runAtLaunch() {
        // uninstall.sh 起的注销登录项辅助进程:只注销就退出,不碰数据。
        guard !CommandLine.arguments.contains("--unregister-login-item") else { return }
        let roots = LyrimusePaths.storageRoots
        let pruned = StorageMigration.pruneRewriteBackups(in: StorageLayout.activeDataDir(roots))
        if pruned > 0 { logger.notice("storage migration: removed \(pruned, privacy: .public) old rewrite backup(s)") }
        guard StorageMigration.isPending(roots) else { return }
        terminateOtherInstances(timeout: 10)
        let lockDir = StorageLayout.activeDataDir(roots)
        _ = ProcessRunner.run(
            "/bin/launchctl", ["bootout", "gui/\(getuid())/\(LyrimuseIdentity.engineLaunchdLabel)"], timeout: 15)
        guard let lock = acquireEngineLock(in: lockDir, timeout: 10) else {
            logger.error("storage migration deferred: the engine still holds the lock in \(lockDir.path, privacy: .public)")
            return
        }
        defer { if lock >= 0 { close(lock) } }

        let outcome = StorageMigration.run(roots)
        logger.notice("""
            storage migration: movedRoot=\(outcome.movedRoot, privacy: .public) copiedRoot=\(outcome.copiedRoot, privacy: .public) \
            merged=\(outcome.mergedItems, privacy: .public) conflicts=\(outcome.conflicts, privacy: .public) \
            leftover=\(outcome.keptLeftover ?? "-", privacy: .public) backup=\(outcome.rewriteBackup ?? "-", privacy: .public) \
            rewrittenFiles=\(outcome.rewrittenFiles, privacy: .public) relocatedCaches=\(outcome.relocatedCaches, privacy: .public) \
            data=\(StorageLayout.activeDataDir(roots).path, privacy: .public)
            """)
        for failure in outcome.failures {
            logger.error("storage migration: \(failure, privacy: .public)")
        }
        if outcome.changedAnything {
            UserDefaults.standard.removeObject(forKey: EngineServiceManager.installedFingerprintKey)
        }
    }

    /// 同一个 bundle id 的其它 App 进程(多半是升级前的旧版本):请它退出,等到真退了;超时就强退再等一小会儿。这时还没有
    /// 运行循环,不能靠 `NSRunningApplication.isTerminated`(它靠运行循环更新),按 pid 用 `kill(pid, 0)` 查。
    static func terminateOtherInstances(timeout: TimeInterval) {
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == LyrimuseIdentity.bundleIdentifier && $0.processIdentifier != getpid()
        }
        guard !others.isEmpty else { return }
        func alive(_ app: NSRunningApplication) -> Bool { kill(app.processIdentifier, 0) == 0 }
        func wait(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while others.contains(where: alive), Date() < deadline { usleep(100_000) }
        }
        for app in others {
            logger.notice("storage migration: asking pid \(app.processIdentifier, privacy: .public) to quit first")
            app.terminate()
        }
        wait(timeout)
        for app in others where alive(app) {
            logger.error("storage migration: pid \(app.processIdentifier, privacy: .public) did not quit, forcing")
            app.forceTerminate()
        }
        wait(3)
    }

    /// 拿引擎的单实例锁(跟 `lyrimuse-engine/singleinstance.go` 同一把 flock),等到拿到或超时。目录里没有锁文件、
    /// 也建不了时说明这里没有引擎在跑,返回 -1 表示「不用锁」;超时返回 nil。
    static func acquireEngineLock(in dir: URL, timeout: TimeInterval) -> Int32? {
        let path = dir.appendingPathComponent("collector.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return errno == ENOENT ? -1 : nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(50_000)
        }
        return fd
    }
}
