import Foundation
import LyrimuseCore

/// 钥匙串锁着时(数据目录里有 `KeychainLock` 的提示文件)每分钟看一次,解锁了就删掉提示文件(引擎下一次重试就去读保险箱),
/// 再补读一次账号凭据和 Apple Music 令牌。没有提示文件时只多一次 lstat。见 15 章决策 73。
///
/// 查文件、查锁、读保险箱(起 `security` 子进程)都在后台,上一次没查完不再派;主线程上的补读只用读进缓存的那份
/// (14 章决策 194)。
@MainActor
enum KeychainUnlockWatcher {
    private static var timer: Timer?
    private static let checks = SingleFlightBackgroundRead<Bool>()

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    static func tick() {
        checks.start(read: { unlockedSinceHint() }) { unlocked in
            guard unlocked else { return }
            ConfigStore.shared.reloadIfVaultWasUnreadable()
            AppleMusicConnection.shared.refresh()
        }
    }

    /// 有提示文件、钥匙串此刻已解锁:顺手把保险箱读进缓存,返回 true。会碰磁盘、可能起子进程,别在主线程调。
    nonisolated static func unlockedSinceHint() -> Bool {
        let dir = LyrimusePaths.configDir
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(KeychainLock.hintFileName).path),
              !KeychainLock.check(hintIn: dir) else { return false }
        _ = CredentialVaultStore.shared.load()
        return true
    }
}
