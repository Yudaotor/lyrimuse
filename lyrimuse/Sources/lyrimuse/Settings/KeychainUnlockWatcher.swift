import Foundation
import LyrimuseCore

/// 钥匙串锁着时(数据目录里有 `KeychainLock` 的提示文件)每分钟看一次,解锁了就删掉提示文件(引擎下一次重试就去读保险箱),
/// 再补读一次账号凭据和 Apple Music 令牌。没有提示文件时只多一次 lstat。见 15 章决策 73。
@MainActor
enum KeychainUnlockWatcher {
    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    static func tick() {
        let dir = LyrimusePaths.configDir
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(KeychainLock.hintFileName).path),
              !KeychainLock.check(hintIn: dir) else { return }
        ConfigStore.shared.reloadIfVaultWasUnreadable()
        AppleMusicConnection.shared.refresh()
    }
}
